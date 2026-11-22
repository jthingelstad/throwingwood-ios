-- The thrower's view frame. Throwing code (the throw scene, cameras, flight,
-- the HUD) always throws from y = 0 toward +y. Team A throws from y = 0 in
-- the world frame already; for Team B the whole pitch is turned 180 degrees
-- about its center, (x, y) -> (-x, 8 - y), angles + pi, so Team B's baseline
-- is at y = 0 of its view. The turn is its own inverse: the same functions
-- convert world -> view and view -> world. The six stakes, the king's spot
-- and the base kubb spots map onto themselves (b3 lands where a3 stands).
-- Pure Lua: no playdate.*.
import "core/tw"
import "core/pitch"

local pi = math.pi

local frame = {}

local LEN = tw.pitch.length

-- (x, y) in the other frame for `side` ("A" is the identity).
function frame.point(side, x, y)
	if side == "B" then return -x, LEN - y end
	return x, y
end

-- A y coordinate alone (a throwing or advantage line).
function frame.y(side, y)
	if side == "B" then return LEN - y end
	return y
end

-- An angle (radians from +x) in the other frame, kept in (-pi, pi].
function frame.angle(side, a)
	a = a or 0
	if side == "B" then a = a + pi end
	while a > pi do a = a - 2 * pi end
	while a <= -pi do a = a + 2 * pi end
	return a
end

-- An engine pose ({x, y, standing, angle, onTop}) in the other frame: a new table.
function frame.pose(side, p)
	local x, y = frame.point(side, p.x, p.y)
	return { x = x, y = y, standing = p.standing, angle = frame.angle(side, p.angle), onTop = p.onTop }
end

-- A body orientation in the other frame: the half turn about z applied on
-- the left, (0, 0, 0, 1) * q.
function frame.quat(side, qw, qx, qy, qz)
	if side == "B" then return -qz, -qy, qx, qw end
	return qw, qx, qy, qz
end

tw.frame = frame
