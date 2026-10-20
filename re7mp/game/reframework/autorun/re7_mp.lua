-- RE7 Co-op for REFramework.  Entry point (reframework/autorun/re7_mp.lua).
-- Needs the native plugin reframework/plugins/re7_mp.dll, which provides the global `mp_net`.

package.path = package.path .. ";./reframework/autorun/?.lua"

if not mp_net then
    log.error("[re7_mp] mp_net is missing: reframework/plugins/re7_mp.dll did not load")
    re.on_draw_ui(function()
        if imgui.tree_node("RE7 Co-op") then
            imgui.text_colored("re7_mp.dll plugin is not loaded - see the REFramework log.", 0xFF4040FF)
            imgui.text("Expected at: <game folder>/reframework/plugins/re7_mp.dll")
            imgui.tree_pop()
        end
    end)
    return
end

local mathx = require("re7_mp/mathx")
local config = require("re7_mp/config")
local session = require("re7_mp/session")
local avatars = require("re7_mp/avatars")
local ui = require("re7_mp/ui")

local cfg = config.load()

-- Monotonic seconds. Prefer the engine's own uptime clock: os.clock() is CPU time on some
-- platforms (possibly under Wine/Proton), which would stall every timeout in this mod.
local app_td = sdk.find_type_definition("via.Application")
local app_singleton = sdk.get_native_singleton("via.Application")
local engine_clock_ok = (app_td ~= nil and app_singleton ~= nil)
local function now_seconds()
    if engine_clock_ok then
        local ok, t = pcall(sdk.call_native_func, app_singleton, app_td, "get_UpTimeSecond")
        if ok and type(t) == "number" then return t end
        engine_clock_ok = false
        log.warn("[re7_mp] engine clock unavailable, falling back to os.clock()")
    end
    return os.clock()
end

local last = now_seconds()

re.on_frame(function()
    local now = now_seconds()
    local dt = math.min(math.max(now - last, 0.0), 0.25)  -- clamp so a loading-screen hitch doesn't fling avatars
    last = now

    session.update(now, dt, cfg)

    local pos = session.head and session.head.pos or nil
    local fwd = session.head and mathx.qrot(session.head.rot, mathx.FORWARD) or nil

    ui.hotkeys(session, pos, fwd)
    avatars.draw(session, cfg, pos)
    ui.draw_overlay(session, cfg)
end)

re.on_draw_ui(function() ui.draw_menu(session, cfg) end)

re.on_script_reset(function()
    mp_net.stop()
    config.save(cfg)
end)

log.info("[re7_mp] loaded - " .. tostring(mp_net.version))
