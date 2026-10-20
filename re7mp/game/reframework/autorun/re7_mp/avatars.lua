-- Remote player rendering.
--
-- Backends implement  draw(session, cfg)  and are called every frame from re.on_frame.
--
--   overlay : ImGui draw-list skeleton + nameplates + markers. Works with zero game assets, but it is
--             a 2D overlay on the desktop window, so it is NOT visible inside a VR headset.
--   world   : (not implemented) real GameObjects in the scene. This is the backend VR players need.
--             See the skeleton at the bottom for what it has to do; the network and pose pipeline
--             already deliver everything it needs (head + both hands, world space, smoothed).

local mathx = require("re7_mp/mathx")
local pose = require("re7_mp/pose")

local A = { backends = {} }

-- ImGui colours are 0xAABBGGRR.
local PALETTE = {
    0xFF4040FF, 0xFF40E040, 0xFFFF8040, 0xFF40D8FF, 0xFFFF40FF, 0xFFFFE040, 0xFF8080FF, 0xFFA0FFA0,
}
local GREY  = 0xFF909090
local WHITE = 0xFFFFFFFF
local BODY_HEIGHT = 1.65  -- metres from eye height to the floor for a standing player

local function colour_for(id) return PALETTE[(id % #PALETTE) + 1] end

-- ------------------------------------------------------------------ projection
local function project(p)
    local s = draw.world_to_screen(Vector3f.new(p.x, p.y, p.z))
    if s then return s.x, s.y end
    return nil
end

local function line3(a, b, col, thick)
    local x1, y1 = project(a)
    local x2, y2 = project(b)
    if x1 and x2 then draw.line(x1, y1, x2, y2, col, thick or 2) end
end

local function text_centered(str, x, y, col)
    draw.text(str, x - (#str * 3.5), y, col)
end

-- ------------------------------------------------------------------ pose helpers
-- Flat-screen players do not send hands; give them a relaxed pair in front of the body.
local function synth_hands(head)
    local yaw = mathx.yaw_quat(head.rot)
    local function off(x, y, z) return mathx.add(head.pos, mathx.qrot(yaw, mathx.v3(x, y, z))) end
    return { pos = off(-0.22, -0.50, 0.38), rot = yaw }, { pos = off(0.22, -0.50, 0.38), rot = yaw }
end

-- ------------------------------------------------------------------ overlay backend
local overlay = {}

local function draw_player(p, cfg, now)
    local c = p.cur
    if not c then return end
    local stale = (now - p.last_rx) > 3.0
    local col = stale and GREY or colour_for(p.id)
    local head = c.head
    local up = mathx.UP
    local yaw = mathx.yaw_quat(head.rot)
    local right = mathx.qrot(yaw, mathx.RIGHT)
    local fwd = mathx.qrot(head.rot, mathx.FORWARD)

    local lh, rh
    if pose.has(p.flags, pose.FLAG_HANDS_VALID) then lh, rh = c.lhand, c.rhand
    else lh, rh = synth_hands(head) end

    local neck = mathx.sub(head.pos, mathx.scale(up, 0.22))
    local hip = mathx.sub(head.pos, mathx.scale(up, 0.95))
    local floor_y = head.pos.y - BODY_HEIGHT
    local lsh = mathx.sub(neck, mathx.scale(right, 0.20))
    local rsh = mathx.add(neck, mathx.scale(right, 0.20))
    local lfoot = mathx.v3(hip.x - right.x * 0.12, floor_y, hip.z - right.z * 0.12)
    local rfoot = mathx.v3(hip.x + right.x * 0.12, floor_y, hip.z + right.z * 0.12)

    line3(neck, hip, col, 3)
    line3(lsh, rsh, col, 3)
    line3(lsh, lh.pos, col, 2)
    line3(rsh, rh.pos, col, 2)
    line3(hip, lfoot, col, 2)
    line3(hip, rfoot, col, 2)
    line3(head.pos, mathx.add(head.pos, mathx.scale(fwd, 0.35)), WHITE, 2)  -- where they are looking

    -- head: size the circle by projecting a point one head-radius above the centre
    local hx, hy = project(head.pos)
    if hx then
        local tx, ty = project(mathx.add(head.pos, mathx.scale(up, 0.12)))
        local r = tx and math.max(3, math.abs(ty - hy)) or 6
        draw.filled_circle(hx, hy, r, col, 16)
        for _, h in ipairs({ lh, rh }) do
            local x, y = project(h.pos)
            if x then draw.filled_circle(x, y, math.max(2, r * 0.45), col, 10) end
        end

        if cfg.show_nameplates then
            local dist = mathx.dist(head.pos, A.viewer_pos or head.pos)
            local label = p.name
            if pose.has(p.flags, pose.FLAG_VR) then label = label .. " [VR]" end
            if stale then label = label .. " (no signal)" end
            if A.viewer_pos then label = label .. string.format("  %dm", math.floor(dist + 0.5)) end
            text_centered(label, hx, hy - r - 18, col)
        end
    end
end

local function draw_markers(session)
    for _, m in ipairs(session.markers) do
        local x, y = project(m.pos)
        if x then
            local col = colour_for(m.owner or 0)
            local s = 9
            draw.line(x, y - s, x + s, y, col, 2)
            draw.line(x + s, y, x, y + s, col, 2)
            draw.line(x, y + s, x - s, y, col, 2)
            draw.line(x - s, y, x, y - s, col, 2)
            local label = session.name_of(m.owner)
            if A.viewer_pos then label = label .. string.format("  %dm", math.floor(mathx.dist(m.pos, A.viewer_pos) + 0.5)) end
            text_centered(label, x, y + s + 3, col)
        end
    end
end

function overlay.draw(session, cfg)
    for _, p in pairs(session.players) do draw_player(p, cfg, session.now) end
    draw_markers(session)
end

A.backends.overlay = overlay

-- ------------------------------------------------------------------ world backend (TODO, needed for VR viewers)
-- A.backends.world should:
--   * create(id):   instantiate a GameObject for the player (a prefab or a mesh component) once on "joined"
--   * update(p):    each frame set its via.Transform position/rotation from p.cur.head (body yaw from
--                   mathx.yaw_quat), and place two hand objects at p.cur.lhand / p.cur.rhand
--                   (use synth_hands() when pose.FLAG_HANDS_VALID is not set)
--   * destroy(id):  destroy the GameObject on "left" / disconnect
-- Because it renders real geometry in the scene, it also shows up in the headset - the overlay does not.

-- ------------------------------------------------------------------ entry point
function A.draw(session, cfg, viewer_pos)
    A.viewer_pos = viewer_pos
    local backend = A.backends[cfg.avatar_backend] or A.backends.overlay
    backend.draw(session, cfg)
end

return A
