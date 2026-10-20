-- Small vector / quaternion toolkit on plain tables so it has no dependency on REFramework
-- userdata and can be unit-tested outside the game.
--   vec3 = {x=, y=, z=}      quat = {x=, y=, z=, w=}

local M = {}

-- RE Engine is Y-up and left-handed: +X right, +Y up, +Z forward.
-- If remote hands ever look mirrored, this is the one place to change.
M.RIGHT   = { x = 1, y = 0, z = 0 }
M.UP      = { x = 0, y = 1, z = 0 }
M.FORWARD = { x = 0, y = 0, z = 1 }

function M.v3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
function M.q(x, y, z, w) return { x = x or 0, y = y or 0, z = z or 0, w = w or 1 } end

function M.add(a, b) return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } end
function M.sub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
function M.scale(a, s) return { x = a.x * s, y = a.y * s, z = a.z * s } end
function M.dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
function M.len(a) return math.sqrt(M.dot(a, a)) end
function M.dist(a, b) return M.len(M.sub(a, b)) end

function M.cross(a, b)
    return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x }
end

function M.lerp(a, b, t)
    return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }
end

function M.qconj(q) return { x = -q.x, y = -q.y, z = -q.z, w = q.w } end

function M.qmul(a, b)
    return {
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    }
end

function M.qnormalize(q)
    local l = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
    if l < 1e-8 then return { x = 0, y = 0, z = 0, w = 1 } end
    return { x = q.x / l, y = q.y / l, z = q.z / l, w = q.w / l }
end

-- Rotate vector v by quaternion q.
function M.qrot(q, v)
    local u = { x = q.x, y = q.y, z = q.z }
    local uv = M.cross(u, v)
    local uuv = M.cross(u, uv)
    return {
        x = v.x + 2 * (q.w * uv.x + uuv.x),
        y = v.y + 2 * (q.w * uv.y + uuv.y),
        z = v.z + 2 * (q.w * uv.z + uuv.z),
    }
end

-- Normalised lerp, taking the short way round. Good enough for 30 Hz smoothing.
function M.nlerp(a, b, t)
    local d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    local s = d < 0 and -1 or 1
    return M.qnormalize({
        x = a.x + (s * b.x - a.x) * t,
        y = a.y + (s * b.y - a.y) * t,
        z = a.z + (s * b.z - a.z) * t,
        w = a.w + (s * b.w - a.w) * t,
    })
end

-- Quaternion from three orthonormal basis vectors (the rotated +X, +Y, +Z axes).
function M.quat_from_axes(r, u, f)
    -- Rotation matrix columns are the axes: m00=r.x m01=u.x m02=f.x / m10=r.y ...
    local m00, m01, m02 = r.x, u.x, f.x
    local m10, m11, m12 = r.y, u.y, f.y
    local m20, m21, m22 = r.z, u.z, f.z
    local tr = m00 + m11 + m22
    local q
    if tr > 0 then
        local s = math.sqrt(tr + 1) * 2
        q = { w = 0.25 * s, x = (m21 - m12) / s, y = (m02 - m20) / s, z = (m10 - m01) / s }
    elseif m00 > m11 and m00 > m22 then
        local s = math.sqrt(1 + m00 - m11 - m22) * 2
        q = { w = (m21 - m12) / s, x = 0.25 * s, y = (m01 + m10) / s, z = (m02 + m20) / s }
    elseif m11 > m22 then
        local s = math.sqrt(1 + m11 - m00 - m22) * 2
        q = { w = (m02 - m20) / s, x = (m01 + m10) / s, y = 0.25 * s, z = (m12 + m21) / s }
    else
        local s = math.sqrt(1 + m22 - m00 - m11) * 2
        q = { w = (m10 - m01) / s, x = (m02 + m20) / s, y = (m12 + m21) / s, z = 0.25 * s }
    end
    return M.qnormalize(q)
end

-- Convert a REFramework Vector3f / Quaternion userdata (or any table with x,y,z[,w]) to plain tables.
function M.from_vec(v) return { x = v.x, y = v.y, z = v.z } end
function M.from_quat(q) return { x = q.x, y = q.y, z = q.z, w = q.w } end

-- Yaw only (rotation about +Y) extracted from a quaternion; used for body orientation.
function M.yaw_quat(q)
    local f = M.qrot(q, M.FORWARD)
    local l = math.sqrt(f.x * f.x + f.z * f.z)
    if l < 1e-6 then return { x = 0, y = 0, z = 0, w = 1 } end
    local yaw = math.atan(f.x / l, f.z / l)  -- Lua 5.3+: atan(y, x)
    return { x = 0, y = math.sin(yaw / 2), z = 0, w = math.cos(yaw / 2) }
end

return M
