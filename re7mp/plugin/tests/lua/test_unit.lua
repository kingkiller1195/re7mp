dofile("plugin/tests/lua/mock_reframework.lua")
local check, near = MOCK.check, MOCK.near

print("[mathx]")
local mathx = require("re7_mp/mathx")
local qa = mathx.qnormalize({ x = 0.3, y = 0.5, z = -0.2, w = 0.7 })
local ident = mathx.qmul(qa, mathx.qconj(qa))
check(near(ident.w, 1) and near(ident.x, 0) and near(ident.y, 0) and near(ident.z, 0), "q * conj(q) = identity")
local v = mathx.qrot(qa, mathx.v3(1, 2, 3))
local back = mathx.qrot(mathx.qconj(qa), v)
check(near(back.x, 1) and near(back.y, 2) and near(back.z, 3), "rotate then inverse-rotate returns the vector")
check(near(mathx.len(v), math.sqrt(14)), "rotation preserves length")
-- 90 degrees about +Y: forward (+Z) -> +X
local s = math.sin(math.pi / 4)
local yaw90 = { x = 0, y = s, z = 0, w = s }
local f = mathx.qrot(yaw90, mathx.FORWARD)
check(near(f.x, 1) and near(f.z, 0), "90 deg yaw sends +Z to +X")
local axes_q = mathx.quat_from_axes(mathx.qrot(qa, mathx.RIGHT), mathx.qrot(qa, mathx.UP), mathx.qrot(qa, mathx.FORWARD))
local dotq = math.abs(axes_q.x * qa.x + axes_q.y * qa.y + axes_q.z * qa.z + axes_q.w * qa.w)
check(near(dotq, 1, 1e-6), "quat_from_axes reconstructs the original rotation")
local yq = mathx.yaw_quat({ x = 0.2, y = s * 0.9, z = 0.1, w = s * 0.9 })
check(near(yq.x, 0) and near(yq.z, 0), "yaw_quat has no pitch/roll component")
local mid = mathx.nlerp({ x = 0, y = 0, z = 0, w = 1 }, yaw90, 0.5)
check(near(mathx.qrot(mid, mathx.FORWARD).x, math.sin(math.pi / 4), 1e-3), "nlerp halfway = 45 deg")
local neg = mathx.nlerp({ x = 0, y = 0, z = 0, w = 1 }, { x = 0, y = 0, z = 0, w = -1 }, 0.5)
check(near(neg.w, 1), "nlerp takes the short way around (q and -q)")

print("[pose]")
local pose = require("re7_mp/pose")
local arr = {}
local head = { pos = { x = 1, y = 2, z = 3 }, rot = { x = 0.1, y = 0.2, z = 0.3, w = 0.9 } }
local lh = { pos = { x = 4, y = 5, z = 6 }, rot = { x = 0, y = 0, z = 0, w = 1 } }
pose.pack(arr, head, lh, nil)
check(#arr == 21, "packed pose has 21 numbers")
local up = pose.unpack(arr)
check(up.head.pos.y == 2 and up.lhand.pos.z == 6 and up.rhand.pos.x == 1, "round trip; missing hand falls back to head")
check(pose.has(9, pose.FLAG_IN_GAME) and pose.has(9, pose.FLAG_VR) and not pose.has(9, pose.FLAG_HANDS_VALID), "flag bits")

print("[config]")
local config = require("re7_mp/config")
local cfg = config.load()
check(cfg.port == 7777 and cfg.max_players == 4 and cfg.avatar_backend == "overlay", "defaults load when no file exists")
json.load_file = function() return { port = 9000, name = 42, bogus = true } end
local cfg2 = config.load()
check(cfg2.port == 9000, "valid saved value is applied")
check(cfg2.name == "Player", "wrong-typed saved value is rejected")
check(cfg2.bogus == nil, "unknown keys are ignored")
json.load_file = function() return nil end

print("[tracking]")
local tracking = require("re7_mp/tracking")
MOCK.camera.pos = { x = 10, y = 1.7, z = -4 }
local a = {}
local flags, h = tracking.sample(a)
check(pose.has(flags, pose.FLAG_IN_GAME) and not pose.has(flags, pose.FLAG_VR), "flat player: in-game, not VR")
check(a[1] == 10 and near(a[2], 1.7) and a[3] == -4 and a[7] == 1, "head pose comes from the camera")
check(not pose.has(flags, pose.FLAG_HANDS_VALID), "flat player does not claim real hands")
MOCK.no_camera = true
check(tracking.sample({}) == nil, "no camera (loading screen) -> no pose sent")
MOCK.no_camera = false

print("[tracking: VR branch fails closed when vrmod is missing/broken]")
check(tracking.vr_active() == false, "no vrmod -> not VR")
vrmod = { is_hmd_active = function() return true end, is_using_controllers = function() error("boom") end }
local f2 = tracking.sample({})
check(pose.has(f2, pose.FLAG_VR) and not pose.has(f2, pose.FLAG_HANDS_VALID), "HMD active but hands API throws -> VR flag, no hands, no crash")

print("[tracking: VR hands, identity case]")
-- Fake 4x4s (row-vector convention): HMD at origin facing +Z, hands 0.3 m left/right and 0.4 m forward.
local function mat(px, py, pz) return { [0] = { x = 1, y = 0, z = 0 }, [1] = { x = 0, y = 1, z = 0 }, [2] = { x = 0, y = 0, z = 1 }, [3] = { x = px, y = py, z = pz } } end
vrmod = {
    is_hmd_active = function() return true end,
    is_using_controllers = function() return true end,
    get_left_controller_index = function() return 1 end,
    get_right_controller_index = function() return 2 end,
    get_transform = function(_, i)
        if i == 0 then return mat(0, 1.6, 0) elseif i == 1 then return mat(-0.3, 1.2, 0.4) else return mat(0.3, 1.2, 0.4) end
    end,
}
MOCK.camera.pos = { x = 100, y = 1.6, z = 50 }
MOCK.camera.rot = { x = 0, y = s, z = 0, w = s }  -- game camera yawed 90 deg: forward is now +X
local arr3 = {}
local f3 = tracking.sample(arr3)
check(pose.has(f3, pose.FLAG_HANDS_VALID), "VR hands valid")
-- hand offsets are re-expressed relative to the head: 0.4 ahead of the head -> +X in world after the yaw
check(near(arr3[8], 100.4, 1e-3) and near(arr3[9], 1.2, 1e-3), "left hand: 0.4 m ahead of the (yawed) head, 0.4 m below")
check(near(arr3[10], 50 + 0.3, 1e-3) or near(arr3[10], 50 - 0.3, 1e-3), "left hand: 0.3 m to the side")
check(near(arr3[8 + 7], 100.4, 1e-3), "right hand: also 0.4 m ahead")
check(arr3[10] ~= arr3[17], "left and right hands are on opposite sides")
vrmod = nil
MOCK.camera.rot = { x = 0, y = 0, z = 0, w = 1 }

print("\nUNIT TESTS PASSED")
