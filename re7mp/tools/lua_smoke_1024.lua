-- Checks of build 10.24 (release 0.11 unchanged) for lua/re7mp.lua, run by tools/lua_smoke.lua (run_1024_file) with that file's helpers in one table.
--   RE7MP_ONLY_1024=1 luarun tools/lua_smoke.lua lua/re7mp.lua      runs only this file (seconds, not minutes)
-- What the build changed in the SCRIPT (the alpha button itself is in re7mp.exe and is tested in tests/core_tests.cpp, test_alpha_channel), and what this file
-- checks (all of it AS THE FAKE GAME ANSWERS; nothing here has been seen in the real game):
--   V. the version: release 0.11 (unchanged), build 10.24
--   C. re7mp_channel.json (written by re7mp.exe): the debug file and the panel say which channel and which exe build it is on; a missing, damaged or unknown
--      file says nothing; the channel is only SAID: nothing in the game depends on it
--   B. the other player on another BUILD of the same release: a note in the panel and the log (never a problem, never for another release)

local H = ...
local check, new_environment, build_world, load_script, host_role_files = H.check, H.new_environment, H.build_world, H.load_script, H.host_role_files
local run_frames, run_ui, ui_has, log_has, push_msgs, bump_remote = H.run_frames, H.run_ui, H.ui_has, H.log_has, H.push_msgs, H.bump_remote

local function live(env, secs)
    for _ = 1, math.floor(secs / 0.05 + 0.5) do
        run_frames(env, 0.05)
        bump_remote(env)
    end
end

-- the debug file after a fresh dump (the same trick the 10.23 file uses: clearing the log makes the script write it again)
local function debug_of(env)
    run_frames(env, 1.2)
    env.ui_press["Clear the debug log"] = true
    run_ui(env)
    run_frames(env, 0.6)
    return env.files["re7mp/debug.json"]
end

local function world(role, setup)
    local env = new_environment()
    build_world(env)
    if setup then setup(env) end
    load_script(env)
    host_role_files(env, role, "tcp")
    live(env, 1.5)
    return env
end

local CHAN = "re7mp_channel.json"

-- =============================================================================================
-- V. the version
-- =============================================================================================
do
    local env = world("host")
    local d = debug_of(env)
    check(d and d.release == "0.11" and d.build == "10.27" and d.script == "re7mp v10.27", "(10.24) the debug file says release 0.11 (unchanged), build 10.27: " .. tostring(d and d.release) .. " / " .. tostring(d and d.build))
    run_ui(env)
    check(ui_has(env, "Release v0.11   (script build 10.27"), "(10.24) the panel shows release v0.11 and build 10.27")
end

-- =============================================================================================
-- C. the channel file
-- =============================================================================================
do
    -- no file (the script runs without the exe, or the exe has not been started since this build): nothing is said, nothing is invented
    local env = world("host")
    live(env, 12)
    local d = debug_of(env)
    check(d.channel == nil and d.exe_build == nil, "(10.24 channel) no file: the debug file has no channel and no exe_build")
    local t = d.health and d.health.channel_tick
    check(t and t.channel == nil and t.exe_build == nil and t.script_build == "10.27" and t.build_matches_exe == nil and t.changes == 0,
        "(10.24 channel) ...and its section says it has not been told (script build 10.27, no match claimed)")
    run_ui(env)
    check(not ui_has(env, "ALPHA channel"), "(10.24 channel) ...and the panel has no alpha line")

    -- "stable", the same build as the script: said in the debug file, no alpha line
    local es = world("host", function(e) e.files[CHAN] = { channel = "stable", exe_build = "10.27", seq = 1 } end)
    live(es, 3)
    local ds = debug_of(es)
    local ts = ds.health and ds.health.channel_tick
    check(ds.channel == "stable" and ds.exe_build == "10.27", "(10.24 channel) a stable exe: channel stable, exe_build 10.24 in the debug file: " .. tostring(ds.channel) .. " / " .. tostring(ds.exe_build))
    check(ts and ts.build_matches_exe == true and ts.changes == 1 and ts.seq == 1, "(10.24 channel) ...its section says the exe and the script are the same build, read once")
    run_ui(es)
    check(not ui_has(es, "ALPHA channel"), "(10.24 channel) ...and the panel has no alpha line")
    check(log_has(es, "channel: re7mp.exe says: channel stable, re7mp.exe build 10.27"), "(10.24 channel) ...and the log says what the exe said")

    -- "alpha": the panel says so at the top, the debug file too
    local ea = world("host", function(e) e.files[CHAN] = { channel = "alpha", exe_build = "10.27", seq = 2 } end)
    live(ea, 3)
    local da = debug_of(ea)
    check(da.channel == "alpha" and da.exe_build == "10.27", "(10.24 channel) an alpha exe: channel alpha in the debug file: " .. tostring(da.channel))
    run_ui(ea)
    check(ui_has(ea, "ALPHA channel (re7mp.exe build 10.27): expect things to break; send debug.json from both players with what you were doing."), "(10.24 channel) ...and the panel has the alpha line")
    check(log_has(ea, "channel: re7mp.exe says: channel alpha, re7mp.exe build 10.27"), "(10.24 channel) ...and the log says it")

    -- it only SAYS it: the game-facing state is the same on both channels
    local ha, hs = da.health.enemy_sync_tick, ds.health.enemy_sync_tick
    check(ha.enemy_mode_now == hs.enemy_mode_now and ha.drive_ai_now == hs.drive_ai_now and ha.molded_on_now == hs.molded_on_now,
        "(10.24 channel) the channel changes nothing in the game: the enemy mode, the AI switch and the Molded copies are the same on alpha and stable")

    -- the exe is another build than the script (the script was dropped in alone): the debug file says so
    local ex = world("host", function(e) e.files[CHAN] = { channel = "alpha", exe_build = "10.23", seq = 3 } end)
    live(ex, 3)
    local dx = debug_of(ex)
    check(dx.health.channel_tick.build_matches_exe == false and dx.exe_build == "10.23", "(10.24 channel) an exe of build 10.23 beside a 10.24 script: build_matches_exe is false")
    run_ui(ex)
    check(ui_has(ex, "re7mp.exe build 10.23"), "(10.24 channel) ...and the alpha line names the exe's build")

    -- it changes while the game runs (the button was used, or the exe was updated): read again within 10 s, said once per change
    local ec = world("host", function(e) e.files[CHAN] = { channel = "stable", exe_build = "10.27", seq = 1 } end)
    live(ec, 3)
    ec.files[CHAN] = { channel = "alpha", exe_build = "10.27", seq = 2 }
    live(ec, 11)
    local dc = debug_of(ec)
    check(dc.channel == "alpha" and dc.health.channel_tick.changes == 2, "(10.24 channel) the exe joins the alpha while the game runs: alpha within 10 s, two changes so far: " .. tostring(dc.channel) .. " / " .. tostring(dc.health.channel_tick.changes))
    live(ec, 25)
    check(debug_of(ec).health.channel_tick.changes == 2, "(10.24 channel) ...and reading the same file again is not a change")
    ec.files[CHAN] = { channel = "stable", exe_build = "10.27", seq = 3 }
    live(ec, 11)
    run_ui(ec)
    check(debug_of(ec).channel == "stable" and not ui_has(ec, "ALPHA channel"), "(10.24 channel) ...and leaving it takes the alpha line away again")

    -- a damaged or unknown file is not believed: the last good answer stays
    ec.files[CHAN] = { channel = "alpha", exe_build = "10.27", seq = 4 }
    live(ec, 11)
    check(debug_of(ec).channel == "alpha", "(10.24 channel) (alpha again)")
    for _, bad in ipairs({ { channel = "beta", exe_build = "10.27" }, { channel = 5 }, { exe_build = "10.27" }, "garbage", 12, {} }) do
        ec.files[CHAN] = bad
        live(ec, 11)
        check(debug_of(ec).channel == "alpha", "(10.24 channel) a file that says " .. (type(bad) == "table" and tostring(bad.channel or "nothing useful") or tostring(bad)) .. " changes nothing: still alpha")
    end
    -- a build label that is not a plain label is dropped (it goes into a file and a panel line); the channel word itself is still taken
    ec.files[CHAN] = { channel = "alpha", exe_build = '10.24"}, {"x', seq = 5 }
    live(ec, 11)
    local dh = debug_of(ec)
    check(dh.channel == "alpha" and dh.exe_build == nil, "(10.24 channel) an exe_build with quotes and braces in it is not used")
    ec.files[CHAN] = { channel = "alpha", exe_build = string.rep("1", 40), seq = 6 }
    live(ec, 11)
    check(debug_of(ec).exe_build == nil, "(10.24 channel) ...nor one that is 40 characters long")
end

-- =============================================================================================
-- B. the other player on another build of the same release
-- =============================================================================================
do
    local function connected(env, n)
        for _ = 1, n do
            run_frames(env, 0.05)
            bump_remote(env)
        end
    end
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    connected(env, 30)

    push_msgs(env, { { 8, "v|0.11|10.23|0.11|6" } })  -- Bob: the same release, the build before this one
    connected(env, 10)
    run_ui(env)
    check(ui_has(env, "Bob runs script build 10.23 and you run 10.27 (the same release)"), "(10.24 builds) another build of the same release: a note in the panel")
    check(not ui_has(env, "update so you both run the same version"), "(10.24 builds) ...and it is not called a problem")
    check(log_has(env, "version: Bob runs script build 10.23 and you run 10.27"), "(10.24 builds) ...and it is logged")

    push_msgs(env, { { 8, "v|0.11|10.27|0.11|6" } })  -- Bob updates to the same build
    connected(env, 10)
    run_ui(env)
    check(not ui_has(env, "runs script build"), "(10.24 builds) the same build: no note")

    push_msgs(env, { { 8, "v|0.5|9.1|0.5|6" } })  -- another RELEASE: the problem is shown, and the build note is not added to it
    connected(env, 10)
    run_ui(env)
    check(ui_has(env, "Bob is on release v0.5 but you are on v0.11: update so you both run the same version") and not ui_has(env, "runs script build"),
        "(10.24 builds) another release: the old warning, without the build note")
    check(not log_has(env, "version: Bob runs script build 9.1"), "(10.24 builds) ...and the log does not say the build note either (it is only for the same release)")
end
