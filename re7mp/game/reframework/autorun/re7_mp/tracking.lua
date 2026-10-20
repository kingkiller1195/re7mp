-- Local player tracking. This is the ONLY file that knows whether the local player is on a flat
-- screen or in VR; everything downstream (network, avatars) just consumes poses.
--
--   flat  : head = primary camera transform. Hands are not sent (receivers synthesise them).
--   VR    : head = primary camera transform (REFramework's VR mod drives the camera from the HMD,
--           so the camera IS the head in world space). Hands = controller poses re-expressed
--           relative to the HMD and re-applied to the head, which avoids depending on how
--           REFramework maps tracking space into game space.
--
-- The VR branch is written against REFramework's `vrmod` Lua object but has NOT been run on real
-- hardware - see the TODO(VR) notes. It is fully guarded with pcall and fails closed to "no hands".

local mathx = require("re7_mp/mathx")
local pose = require("re7_mp/pose")

local T = {}

local function camera_pose()
    local ok, res = pcall(function()
        local cam = sdk.get_primary_camera()
        if not cam then return nil end
        local go = cam:call("get_GameObject")
        if not go then return nil end
        local tf = go:call("get_Transform")
        if not tf then return nil end
        local p, r = tf:call("get_Position"), tf:call("get_Rotation")
        if not p or not r then return nil end
        return { pos = mathx.from_vec(p), rot = mathx.from_quat(r) }
    end)
    return ok and res or nil
end

function T.vr_active()
    if not vrmod then return false end
    local ok, active = pcall(function() return vrmod:is_hmd_active() end)
    return ok and active == true
end

-- Tracking-space 4x4 (REFramework Matrix4x4f) -> {pos, rot}.
-- TODO(VR): assumes row-vector convention: rows 0..2 = right/up/forward axes, row 3 = translation.
-- If hands come out rotated the wrong way, this is the function to adjust (try conjugating rot).
local function pose_from_matrix(m)
    local r0, r1, r2, r3 = m[0], m[1], m[2], m[3]
    return {
        pos = { x = r3.x, y = r3.y, z = r3.z },
        rot = mathx.quat_from_axes(
            { x = r0.x, y = r0.y, z = r0.z },
            { x = r1.x, y = r1.y, z = r1.z },
            { x = r2.x, y = r2.y, z = r2.z }),
    }
end

local function relative_to_head(head, hmd, dev)
    local inv = mathx.qconj(hmd.rot)
    local local_pos = mathx.qrot(inv, mathx.sub(dev.pos, hmd.pos))
    local local_rot = mathx.qmul(inv, dev.rot)
    return {
        pos = mathx.add(head.pos, mathx.qrot(head.rot, local_pos)),
        rot = mathx.qnormalize(mathx.qmul(head.rot, local_rot)),
    }
end

-- Returns left, right (world-space poses) or nil when controllers are not being used.
local function vr_hands(head)
    local ok, lh, rh = pcall(function()
        -- TODO(VR): verify these method names against your REFramework build (Object Explorer ->
        -- vrmod, or the VR section of the REFramework book). Device index 0 is the HMD.
        if not vrmod:is_using_controllers() then return nil end
        local li, ri = vrmod:get_left_controller_index(), vrmod:get_right_controller_index()
        if li == nil or ri == nil or li < 0 or ri < 0 then return nil end
        local hmd = pose_from_matrix(vrmod:get_transform(0))
        local l = pose_from_matrix(vrmod:get_transform(li))
        local r = pose_from_matrix(vrmod:get_transform(ri))
        return relative_to_head(head, hmd, l), relative_to_head(head, hmd, r)
    end)
    if ok and lh and rh then return lh, rh end
    return nil
end

-- Fills `arr` (21 numbers) in place and returns the pose flags, or nil if there is no camera yet
-- (loading screen / title). `arr` is reused every frame to avoid garbage.
function T.sample(arr)
    local head = camera_pose()
    if not head then return nil end
    local flags = pose.FLAG_IN_GAME
    local lh, rh
    if T.vr_active() then
        flags = flags | pose.FLAG_VR
        lh, rh = vr_hands(head)
        if lh then flags = flags | pose.FLAG_HANDS_VALID end
    end
    pose.pack(arr, head, lh, rh)
    return flags, head
end

return T
