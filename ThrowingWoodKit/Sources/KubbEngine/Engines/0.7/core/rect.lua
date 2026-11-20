-- Oriented rectangles on the ground plane, for footprints and obstruction.
-- Pure Lua: no playdate.*. A rect is { x, y, a, hl, hw }: center, angle of the
-- long axis (radians from +x), half-length along that axis, half-width across.
-- Not for per-frame paths: functions return new tables.
import "core/tw"

local cos, sin, sqrt, abs, huge = math.cos, math.sin, math.sqrt, math.abs, math.huge

local rect = {}

-- Overlap closer than this counts as touching, not overlapping.
rect.eps = 1e-6

function rect.new(x, y, a, hl, hw)
	return { x = x, y = y, a = a or 0, hl = hl, hw = hw }
end

function rect.corners(r)
	local c, s = cos(r.a), sin(r.a)
	local ux, uy = c * r.hl, s * r.hl
	local vx, vy = -s * r.hw, c * r.hw
	return {
		{ r.x + ux + vx, r.y + uy + vy },
		{ r.x - ux + vx, r.y - uy + vy },
		{ r.x - ux - vx, r.y - uy - vy },
		{ r.x + ux - vx, r.y + uy - vy },
	}
end

-- Projection half-extent of rect r on unit axis (ax, ay).
local function extent(r, ax, ay)
	local c, s = cos(r.a), sin(r.a)
	return r.hl * abs(c * ax + s * ay) + r.hw * abs(-s * ax + c * ay)
end

-- Separating-axis test. True when the rects overlap by more than eps.
function rect.overlap(p, q)
	local dx, dy = q.x - p.x, q.y - p.y
	for _, r in ipairs { p, q } do
		local c, s = cos(r.a), sin(r.a)
		for _, ax in ipairs { { c, s }, { -s, c } } do
			local d = abs(dx * ax[1] + dy * ax[2])
			if d >= extent(p, ax[1], ax[2]) + extent(q, ax[1], ax[2]) - rect.eps then
				return false
			end
		end
	end
	return true
end

-- Distance from a point to a rect (0 inside).
function rect.pointDistance(r, px, py)
	local c, s = cos(r.a), sin(r.a)
	local dx, dy = px - r.x, py - r.y
	local u = dx * c + dy * s
	local v = -dx * s + dy * c
	local eu = abs(u) - r.hl
	local ev = abs(v) - r.hw
	if eu < 0 then eu = 0 end
	if ev < 0 then ev = 0 end
	return sqrt(eu * eu + ev * ev)
end

-- Smallest distance between two rects (0 when they overlap or touch). For
-- two disjoint convex polygons a closest pair always includes a vertex.
function rect.distance(p, q)
	if rect.overlap(p, q) then return 0 end
	local best = huge
	for _, pair in ipairs { { p, q }, { q, p } } do
		for _, v in ipairs(rect.corners(pair[1])) do
			local d = rect.pointDistance(pair[2], v[1], v[2])
			if d < best then best = d end
		end
	end
	return best
end

tw.rect = rect
