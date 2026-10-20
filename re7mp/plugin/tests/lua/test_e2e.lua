-- Run as two processes:  lua_harness test_e2e.lua host <port>   /   lua_harness test_e2e.lua client <port>
-- Each process loads the REAL entry script (game/reframework/autorun/re7_mp.lua) and the REAL plugin bridge.
dofile("plugin/tests/lua/mock_reframework.lua")
local check = MOCK.check
local role, port = ARGS[1], tonumber(ARGS[2])
local is_host = (role == "host")
local my_name = is_host and "Hostess" or "Client"
local other_name = is_host and "Client" or "Hostess"

json.load_file = function() return { name = my_name, port = port, last_ip = "127.0.0.1" } end
dofile("game/reframework/autorun/re7_mp.lua")
local session = require("re7_mp/session")
check(#MOCK.frame_cbs == 1 and #MOCK.ui_cbs == 1 and #MOCK.reset_cbs == 1, "entry script registered frame/ui/reset callbacks")
check(mp_net.version:find("re7_mp-net", 1, true), "mp_net global provided by the plugin bridge")

-- Start through the real menu code path (the Host / Join buttons)
MOCK.pressed_buttons[is_host and "Host" or "Join"] = true
MOCK.ui()
MOCK.pressed_buttons = {}

local base_x = is_host and 0 or 50
local t0 = wall_clock()
local function elapsed() return wall_clock() - t0 end

local function run(seconds, fn)
    local stop_at = elapsed() + seconds
    while elapsed() < stop_at do
        local t = elapsed()
        MOCK.camera.pos = { x = base_x + t * 1.5, y = 1.6, z = 0 }   -- both players walk along +X
        MOCK.reset_draw()
        MOCK.frame()
        if fn and fn(t) then return true end
        sleep_ms(16)
    end
    return false
end

local function other_player()
    for _, p in pairs(session.players) do return p end
end

-- ---- phase 1: connect
local ok = run(8, function() return other_player() ~= nil and other_player().cur ~= nil end)
check(ok, role .. ": sees the other player and receives their pose")
check(session.state == (is_host and "hosting" or "connected"), "session state is " .. session.state)
check(session.my_id == (is_host and 0 or 1), "my id is " .. tostring(session.my_id))
check(other_player().name == other_name, "roster has the other player's name: " .. other_player().name)

-- ---- phase 2: chat + marker + quick chat through the real hotkey / UI code paths
check(session.send_chat("hello from " .. role), "send_chat accepted")
MOCK.keys[0x75] = true  -- F6 drop marker
run(0.1); MOCK.keys[0x75] = false
if not is_host then
    MOCK.keys[0x76] = true  -- F7 "Help!"
    run(0.1); MOCK.keys[0x76] = false
end
run(1.5)

local function chat_has(text)
    for _, m in ipairs(session.chat) do if m.text == text then return m end end
end
check(chat_has("hello from " .. (is_host and "client" or "host")), "received the other side's chat")
check(chat_has("hello from " .. (is_host and "client" or "host")).who == other_name, "chat attributed to " .. other_name)
if is_host then check(chat_has("Help!") ~= nil, "host received the client's F7 quick-chat") end

local other_marker
for _, m in ipairs(session.markers) do if m.owner == other_player().id then other_marker = m end end
check(other_marker ~= nil, "received the other side's marker (reliable user event)")

-- ---- phase 3: world-space pose is correct, smoothed and drawn
local p = other_player()
local expect_x = (is_host and 50 or 0) + elapsed() * 1.5
check(math.abs(p.cur.head.pos.x - expect_x) < 6, string.format("remote head x=%.1f tracks the remote camera (~%.1f)", p.cur.head.pos.x, expect_x))
check(math.abs(p.cur.head.pos.y - 1.6) < 0.01, "remote head height")
MOCK.reset_draw(); MOCK.frame()
check(MOCK.draw.lines >= 6 and MOCK.draw.circles >= 3, "avatar skeleton is drawn (" .. MOCK.draw.lines .. " lines, " .. MOCK.draw.circles .. " circles)")
check(MOCK.texts_contain(other_name), "nameplate shows the remote player's name")
check(MOCK.texts_contain("Hostess") or MOCK.texts_contain("Client"), "overlay text present")
check(mp_net.poll and #mp_net.poll() == 0, "event queue drained each frame")
if not is_host then check(mp_net.rtt() >= 0, "rtt reported") end

-- ---- phase 4: leaving
if not is_host then
    MOCK.pressed_buttons["Disconnect"] = true
    MOCK.ui()
    MOCK.pressed_buttons = {}
    check(mp_net.state() == "idle" and session.state == "idle", "client: Disconnect button returns to idle")
    print("\nCLIENT E2E OK")
else
    local left = run(6, function() return other_player() == nil end)
    check(left, "host: noticed the client leave")
    check(chat_has("Client left") ~= nil, "host: 'Client left' announced in chat")
    for _, f in ipairs(MOCK.reset_cbs) do f() end   -- REFramework 'Reset scripts'
    check(mp_net.state() == "idle", "script reset tears the session down")
    print("\nHOST E2E OK")
end
