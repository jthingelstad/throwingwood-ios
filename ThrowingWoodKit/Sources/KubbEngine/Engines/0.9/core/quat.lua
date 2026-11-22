-- Unit quaternions for body orientation. Pure Lua: no playdate.*.
--
-- To make no garbage in the physics step, every function takes and returns
-- plain numbers (w, x, y, z), never tables. A quaternion q turns body-local
-- vectors into world vectors: v_world = q v_local q*.
--
-- Rotation matrices are returned as nine numbers, row-major:
-- r11, r12, r13, r21, r22, r23, r31, r32, r33. Column k is the body's local
-- axis k in world coordinates (column 3 = the local z axis).
import "core/tw"

local sqrt, sin, cos = math.sqrt, math.sin, math.cos

local quat = {}

function quat.identity()
	return 1, 0, 0, 0
end

function quat.normalize(w, x, y, z)
	local n = sqrt(w * w + x * x + y * y + z * z)
	if n < 1e-12 then return 1, 0, 0, 0 end
	n = 1 / n
	return w * n, x * n, y * n, z * n
end

-- Hamilton product a * b (apply b first, then a).
function quat.mul(aw, ax, ay, az, bw, bx, by, bz)
	return aw * bw - ax * bx - ay * by - az * bz,
		aw * bx + ax * bw + ay * bz - az * by,
		aw * by - ax * bz + ay * bw + az * bx,
		aw * bz + ax * by - ay * bx + az * bw
end

function quat.conj(w, x, y, z)
	return w, -x, -y, -z
end

-- Rotation by `angle` radians about the unit axis (ax, ay, az).
function quat.fromAxisAngle(ax, ay, az, angle)
	local h = angle * 0.5
	local s = sin(h)
	return cos(h), ax * s, ay * s, az * s
end

-- Rotate the vector (vx, vy, vz) by q.
function quat.rotate(w, x, y, z, vx, vy, vz)
	-- t = 2 (q.xyz x v); v' = v + w t + q.xyz x t
	local tx = 2 * (y * vz - z * vy)
	local ty = 2 * (z * vx - x * vz)
	local tz = 2 * (x * vy - y * vx)
	return vx + w * tx + (y * tz - z * ty),
		vy + w * ty + (z * tx - x * tz),
		vz + w * tz + (x * ty - y * tx)
end

-- The rotation matrix of q (nine numbers, row-major).
function quat.toMatrix(w, x, y, z)
	local xx, yy, zz = x * x, y * y, z * z
	local xy, xz, yz = x * y, x * z, y * z
	local wx, wy, wz = w * x, w * y, w * z
	return 1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy),
		2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx),
		2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy)
end

-- The quaternion of a rotation matrix (row-major). Shepperd's method.
function quat.fromMatrix(r11, r12, r13, r21, r22, r23, r31, r32, r33)
	local tr = r11 + r22 + r33
	local w, x, y, z
	if tr > 0 then
		local s = sqrt(tr + 1) * 2
		w, x, y, z = 0.25 * s, (r32 - r23) / s, (r13 - r31) / s, (r21 - r12) / s
	elseif r11 > r22 and r11 > r33 then
		local s = sqrt(1 + r11 - r22 - r33) * 2
		w, x, y, z = (r32 - r23) / s, 0.25 * s, (r12 + r21) / s, (r13 + r31) / s
	elseif r22 > r33 then
		local s = sqrt(1 + r22 - r11 - r33) * 2
		w, x, y, z = (r13 - r31) / s, (r12 + r21) / s, 0.25 * s, (r23 + r32) / s
	else
		local s = sqrt(1 + r33 - r11 - r22) * 2
		w, x, y, z = (r21 - r12) / s, (r13 + r31) / s, (r23 + r32) / s, 0.25 * s
	end
	return quat.normalize(w, x, y, z)
end

-- The quaternion whose local x, y, z axes are the given world vectors
-- (orthonormal, right-handed: x cross y = z).
function quat.fromAxes(xx, xy, xz, yx, yy, yz, zx, zy, zz)
	return quat.fromMatrix(xx, yx, zx, xy, yy, zy, xz, yz, zz)
end

-- Advance q by the world angular velocity (wx, wy, wz) over dt:
-- q' = q + dt/2 (0, w) q, renormalized.
function quat.integrate(w, x, y, z, wx, wy, wz, dt)
	local h = 0.5 * dt
	local dw = -(wx * x + wy * y + wz * z)
	local dx = wx * w + wy * z - wz * y
	local dy = wy * w + wz * x - wx * z
	local dz = wz * w + wx * y - wy * x
	return quat.normalize(w + h * dw, x + h * dx, y + h * dy, z + h * dz)
end

-- Angle in radians between two orientations.
function quat.angleBetween(aw, ax, ay, az, bw, bx, by, bz)
	local d = math.abs(aw * bw + ax * bx + ay * by + az * bz)
	if d > 1 then d = 1 end
	return 2 * math.acos(d)
end

tw.quat = quat
