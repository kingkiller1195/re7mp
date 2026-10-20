-- Minimal stand-in for the REFramework Lua environment, just enough to run the mod outside the game.
-- (Real REFramework API shapes: re.on_frame / re.on_draw_ui / sdk.get_primary_camera():call(...) /
--  draw.world_to_screen / draw.line / imgui.* / reframework:is_key_down / json.*)

package.path = "game/reframework/autorun/?.lua;" .. package.path

MOCK = {
    frame_cbs = {}, ui_cbs = {}, reset_cbs = {},
    camera = { pos = { x = 0, y = 1.6, z = 0 }, rot = { x = 0, y = 0, z = 0, w = 1 } },
    no_camera = false,
    keys = {},
    pressed_buttons = {},
    draw = { lines = 0, circles = 0, texts = {} },
    logs = {},
}

local function noop() end
log = {
    info = function(m) MOCK.logs[#MOCK.logs + 1] = "I " .. tostring(m) end,
    warn = function(m) MOCK.logs[#MOCK.logs + 1] = "W " .. tostring(m) end,
    error = function(m) MOCK.logs[#MOCK.logs + 1] = "E " .. tostring(m) end,
}

re = {
    on_frame = function(f) MOCK.frame_cbs[#MOCK.frame_cbs + 1] = f end,
    on_draw_ui = function(f) MOCK.ui_cbs[#MOCK.ui_cbs + 1] = f end,
    on_script_reset = function(f) MOCK.reset_cbs[#MOCK.reset_cbs + 1] = f end,
}
function MOCK.frame() for _, f in ipairs(MOCK.frame_cbs) do f() end end
function MOCK.ui() for _, f in ipairs(MOCK.ui_cbs) do f() end end

Vector3f = { new = function(x, y, z) return { x = x, y = y, z = z } end }

-- camera -> game object -> transform, all via :call("name")
local transform = { call = function(_, name)
    if name == "get_Position" then return MOCK.camera.pos end
    if name == "get_Rotation" then return MOCK.camera.rot end
end }
local game_object = { call = function(_, name) if name == "get_Transform" then return transform end end }
local camera = { call = function(_, name) if name == "get_GameObject" then return game_object end end }

sdk = {
    get_primary_camera = function() if MOCK.no_camera then return nil end return camera end,
    find_type_definition = function(n) return { name = n } end,
    get_native_singleton = function(n) return { name = n } end,
    call_native_func = function(_, _, name) if name == "get_UpTimeSecond" then return wall_clock() end end,
}

draw = {
    world_to_screen = function(v) return { x = 960 + v.x * 50, y = 540 - v.y * 50 } end,
    line = function() MOCK.draw.lines = MOCK.draw.lines + 1 end,
    filled_circle = function() MOCK.draw.circles = MOCK.draw.circles + 1 end,
    text = function(t) MOCK.draw.texts[#MOCK.draw.texts + 1] = t end,
}

imgui = {
    tree_node = function() return true end, tree_pop = noop, text = noop, text_colored = noop,
    same_line = noop, separator = noop,
    button = function(label) return MOCK.pressed_buttons[label] == true end,
    input_text = function(_, v) return false, v end,
    checkbox = function(_, v) return false, v end,
    drag_int = function(_, v) return false, v end,
    drag_float = function(_, v) return false, v end,
}

reframework = { is_key_down = function(_, vk) return MOCK.keys[vk] == true end }
json = { load_file = function() return nil end, dump_file = noop }

function MOCK.reset_draw() MOCK.draw = { lines = 0, circles = 0, texts = {} } end
function MOCK.texts_contain(s)
    for _, t in ipairs(MOCK.draw.texts) do if t:find(s, 1, true) then return true end end
    return false
end

function MOCK.check(cond, msg)
    if not cond then error("CHECK FAILED: " .. msg, 2) end
    print("  ok  " .. msg)
end
function MOCK.near(a, b, eps) return math.abs(a - b) <= (eps or 1e-4) end
