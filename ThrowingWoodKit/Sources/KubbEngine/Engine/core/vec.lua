-- 3D vectors in world meters (x across, y downfield, z up).
-- Pure Lua: no playdate.*. Vectors are plain tables {x=, y=, z=}; every
-- function returns a new table and never changes its arguments.
import "core/tw"

local sqrt = math.sqrt

local vec = {}

function vec.new(x, y, z)
	return { x = x or 0, y = y or 0, z = z or 0 }
end

function vec.add(a, b)
	return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

function vec.sub(a, b)
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

function vec.scale(a, s)
	return { x = a.x * s, y = a.y * s, z = a.z * s }
end

function vec.dot(a, b)
	return a.x * b.x + a.y * b.y + a.z * b.z
end

function vec.cross(a, b)
	return {
		x = a.y * b.z - a.z * b.y,
		y = a.z * b.x - a.x * b.z,
		z = a.x * b.y - a.y * b.x,
	}
end

function vec.length(a)
	return sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
end

tw.vec = vec
