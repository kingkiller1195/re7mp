-- REFramework menu panel (press Insert in-game), in-game chat overlay and hotkeys.
-- Hotkeys exist because typing is awkward in VR and with a controller: quick-chat + marker are one key.

local mathx = require("re7_mp/mathx")
local config = require("re7_mp/config")

local U = {}

local chat_input = ""

-- Windows virtual-key codes
local VK = { F6 = 0x75, F7 = 0x76, F8 = 0x77, F9 = 0x78 }
local QUICK_CHAT = {
    [VK.F7] = "Help!",
    [VK.F8] = "Over here!",
    [VK.F9] = "Wait for me!",
}
local key_was_down = {}

local function pressed(vk)
    local down = reframework:is_key_down(vk)
    local edge = down and not key_was_down[vk]
    key_was_down[vk] = down
    return edge
end

-- viewer_pos / viewer_fwd come from the local camera (or nil when there is none)
function U.hotkeys(session, viewer_pos, viewer_fwd)
    if session.state ~= "hosting" and session.state ~= "connected" then return end
    if pressed(VK.F6) and viewer_pos and viewer_fwd then
        session.drop_marker(mathx.add(viewer_pos, mathx.scale(viewer_fwd, 3.0)))
    end
    for vk, msg in pairs(QUICK_CHAT) do
        if pressed(vk) then session.send_chat(msg) end
    end
end

-- ------------------------------------------------------------------ in-game chat overlay
function U.draw_overlay(session, cfg)
    if not cfg.show_chat_overlay then return end
    local y = 24
    for i = math.max(1, #session.chat - 6), #session.chat do
        local m = session.chat[i]
        if session.now - m.t < 12 then
            local line = (m.who == "system") and m.text or (m.who .. ": " .. m.text)
            local col = (m.who == "system") and 0xFFB0B0B0 or 0xFFFFFFFF
            draw.text(line, 24, y, col)
            y = y + 18
        end
    end
end

-- ------------------------------------------------------------------ menu
local function changed_text(label, value)
    local ch, v = imgui.input_text(label, value)
    if ch then return v, true end
    return value, false
end

function U.draw_menu(session, cfg)
    if not imgui.tree_node("RE7 Co-op") then return end

    local dirty = false
    local idle = (session.state == "idle")

    if idle then
        local v, ch
        v, ch = changed_text("Name", cfg.name); if ch then cfg.name = v; dirty = true end
        v, ch = changed_text("Join IP", cfg.last_ip); if ch then cfg.last_ip = v; dirty = true end
        local ch2, port = imgui.drag_int("UDP port", cfg.port, 1, 1024, 65535)
        if ch2 then cfg.port = port; dirty = true end
        local ch3, maxp = imgui.drag_int("Max players", cfg.max_players, 1, 2, 8)
        if ch3 then cfg.max_players = maxp; dirty = true end

        if imgui.button("Host") then session.start_host(cfg) end
        imgui.same_line()
        if imgui.button("Join") then session.start_join(cfg) end
        if session.error then imgui.text_colored(session.error, 0xFF4040FF) end
        imgui.text("Everyone must be at the same point in the game (same save / same room).")
    else
        imgui.text("State: " .. session.state .. "   you are player " .. tostring(session.my_id))
        if session.state == "connected" then imgui.text(string.format("Ping: %.0f ms", mp_net.rtt())) end
        if imgui.button("Disconnect") then session.stop() end

        imgui.separator()
        imgui.text("Players")
        imgui.text("  " .. session.my_name .. " (you)" .. (session.local_flags % 2 == 1 and " [VR]" or ""))
        for id, p in pairs(session.players) do
            local vr = (p.flags % 2 == 1) and " [VR]" or ""
            imgui.text(string.format("  %s%s  (id %d)", p.name, vr, id))
        end

        imgui.separator()
        local v, ch = changed_text("##chat", chat_input)
        if ch then chat_input = v end
        imgui.same_line()
        if imgui.button("Send") and chat_input ~= "" then
            session.send_chat(chat_input)
            chat_input = ""
        end
        imgui.text("Hotkeys: F6 drop marker   F7 'Help!'   F8 'Over here!'   F9 'Wait for me!'")
    end

    imgui.separator()
    local c1, nameplates = imgui.checkbox("Show nameplates", cfg.show_nameplates)
    if c1 then cfg.show_nameplates = nameplates; dirty = true end
    local c2, overlay = imgui.checkbox("Show chat overlay", cfg.show_chat_overlay)
    if c2 then cfg.show_chat_overlay = overlay; dirty = true end
    local c3, smoothing = imgui.drag_float("Avatar smoothing", cfg.pose_smoothing, 0.5, 4.0, 40.0)
    if c3 then cfg.pose_smoothing = smoothing; dirty = true end

    if dirty then config.save(cfg) end
    imgui.tree_pop()
end

return U
