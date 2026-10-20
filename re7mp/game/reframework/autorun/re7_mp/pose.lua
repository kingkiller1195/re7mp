-- The pose that goes over the wire: three tracked points, each position (3) + rotation quat (4):
--   head, left hand, right hand  ->  21 numbers, all in WORLD space.
-- Flat-screen players send the head only (hands are synthesised by the receiver); VR players send
-- real controller poses. Same packet either way - that is what keeps VR a drop-in later.

local M = {}

-- Must match PoseFlags in plugin/src/net.hpp
M.FLAG_VR           = 1
M.FLAG_HANDS_VALID  = 2
M.FLAG_CROUCHED     = 4
M.FLAG_IN_GAME      = 8

local function has(flags, bit) return (flags // bit) % 2 == 1 end
M.has = has

local function put(arr, base, p)
    arr[base + 1], arr[base + 2], arr[base + 3] = p.pos.x, p.pos.y, p.pos.z
    arr[base + 4], arr[base + 5], arr[base + 6], arr[base + 7] = p.rot.x, p.rot.y, p.rot.z, p.rot.w
end

local function get(arr, base)
    return {
        pos = { x = arr[base + 1], y = arr[base + 2], z = arr[base + 3] },
        rot = { x = arr[base + 4], y = arr[base + 5], z = arr[base + 6], w = arr[base + 7] },
    }
end

-- Fills `arr` in place (no per-frame garbage). `lh` / `rh` may be nil -> zeros with identity rotation.
function M.pack(arr, head, lh, rh)
    put(arr, 0, head)
    put(arr, 7, lh or { pos = head.pos, rot = head.rot })
    put(arr, 14, rh or { pos = head.pos, rot = head.rot })
    return arr
end

function M.unpack(arr)
    return { head = get(arr, 0), lhand = get(arr, 7), rhand = get(arr, 14) }
end

return M
